// RFC 6330 Section 5.3.3 - Constraint matrix construction conformance tests
// Verifies LDPC, HDPC, and LT sub-matrix structure within the constraint
// matrices for multiple K' values.

const std = @import("std");
const raptorq = @import("raptorq");
const Octet = raptorq.octet.Octet;
const cm = raptorq.constraint_matrix;
const sc = raptorq.systematic_constants;
const helpers = raptorq.helpers;

test "Constraint matrix dimensions" {
    const k_values = [_]u32{ 10, 18, 46, 101, 500, 1000 };

    for (k_values) |k| {
        const kp = sc.ceilKPrime(k);
        const si = sc.findSystematicIndex(kp).?;
        const h = si.h;
        const l = kp + si.s + si.h;

        var matrices = try cm.buildConstraintMatrices(std.testing.allocator, kp);
        defer matrices.deinit();

        try std.testing.expectEqual(l - h, matrices.binary.numRows());
        try std.testing.expectEqual(l, matrices.binary.numCols());
        try std.testing.expectEqual(h, matrices.hdpc.numRows());
        try std.testing.expectEqual(l, matrices.hdpc.numCols());
    }
}

test "LDPC sub-matrix structure" {
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s = si.s;
    const w = si.w;
    const b = w - s;
    const l = kp + si.s + si.h;
    const p = l - w;

    var matrices = try cm.buildConstraintMatrices(std.testing.allocator, kp);
    defer matrices.deinit();

    // S x S identity block at columns B..B+S-1
    var i: u32 = 0;
    while (i < s) : (i += 1) {
        var j: u32 = 0;
        while (j < s) : (j += 1) {
            if (i == j) {
                try std.testing.expect(matrices.binary.get(i, b + j));
            } else {
                try std.testing.expect(!matrices.binary.get(i, b + j));
            }
        }
    }

    // Each LDPC row has circulant contributions + identity + PI circulant
    i = 0;
    while (i < s) : (i += 1) {
        var circulant_nz: u32 = 0;
        var c: u32 = 0;
        while (c < b) : (c += 1) {
            if (matrices.binary.get(i, c)) circulant_nz += 1;
        }
        try std.testing.expect(circulant_nz >= 1);

        var pi_nz: u32 = 0;
        c = w;
        while (c < w + p) : (c += 1) {
            if (matrices.binary.get(i, c)) pi_nz += 1;
        }
        try std.testing.expect(pi_nz >= 1 and pi_nz <= 2);
    }
}

test "HDPC sub-matrix rows" {
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const h = si.h;
    const kp_s = kp + si.s;

    var matrices = try cm.buildConstraintMatrices(std.testing.allocator, kp);
    defer matrices.deinit();

    // H x H identity block at columns K'+S..K'+S+H-1
    var i: u32 = 0;
    while (i < h) : (i += 1) {
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            if (i == j) {
                try std.testing.expect(matrices.hdpc.get(i, kp_s + j).isOne());
            } else {
                try std.testing.expect(matrices.hdpc.get(i, kp_s + j).isZero());
            }
        }
    }

    // HDPC rows should have nonzeros in columns 0..K'+S-1
    i = 0;
    while (i < h) : (i += 1) {
        var has_nonzero = false;
        var c: u32 = 0;
        while (c < kp_s) : (c += 1) {
            if (!matrices.hdpc.get(i, c).isZero()) {
                has_nonzero = true;
                break;
            }
        }
        try std.testing.expect(has_nonzero);
    }
}

test "Identity block in constraint matrix" {
    const kp: u32 = 26;
    const si = sc.findSystematicIndex(kp).?;
    const s = si.s;
    const h = si.h;
    const l = kp + s + h;

    var matrices = try cm.buildConstraintMatrices(std.testing.allocator, kp);
    defer matrices.deinit();

    // LT rows are at binary rows [S, L-H)
    var row: u32 = s;
    while (row < l - h) : (row += 1) {
        var nz: u32 = 0;
        var c: u32 = 0;
        while (c < l) : (c += 1) {
            if (matrices.binary.get(row, c)) nz += 1;
        }
        try std.testing.expect(nz >= 3);
    }
}

test "Constraint matrix for K'=10" {
    const kp: u32 = 10;

    var encoding = try cm.buildConstraintMatrices(std.testing.allocator, kp);
    defer encoding.deinit();

    var isis: [10]u32 = undefined;
    for (&isis, 0..) |*v, i| v.* = @intCast(i);
    var decoding = try cm.buildDecodingMatrices(std.testing.allocator, kp, &isis);
    defer decoding.deinit();

    const l = encoding.l;
    const binary_rows = encoding.binary.numRows();

    // Binary matrices must match
    var r: u32 = 0;
    while (r < binary_rows) : (r += 1) {
        var c: u32 = 0;
        while (c < l) : (c += 1) {
            try std.testing.expectEqual(encoding.binary.get(r, c), decoding.binary.get(r, c));
        }
    }

    // HDPC matrices must match
    const h = encoding.hdpc.numRows();
    r = 0;
    while (r < h) : (r += 1) {
        var c: u32 = 0;
        while (c < l) : (c += 1) {
            try std.testing.expectEqual(encoding.hdpc.get(r, c).value, decoding.hdpc.get(r, c).value);
        }
    }
}

test "Constraint matrix for K'=100" {
    const kp: u32 = 101;
    const si = sc.findSystematicIndex(kp).?;
    const s = si.s;
    const h = si.h;
    const l = kp + s + h;

    var matrices = try cm.buildConstraintMatrices(std.testing.allocator, kp);
    defer matrices.deinit();

    try std.testing.expectEqual(l - h, matrices.binary.numRows());
    try std.testing.expectEqual(l, matrices.binary.numCols());
    try std.testing.expectEqual(h, matrices.hdpc.numRows());
    try std.testing.expectEqual(l, matrices.hdpc.numCols());

    // LDPC S x S identity block
    const b = si.w - s;
    var i: u32 = 0;
    while (i < s) : (i += 1) {
        try std.testing.expect(matrices.binary.get(i, b + i));
    }

    // HDPC H x H identity block
    i = 0;
    while (i < h) : (i += 1) {
        try std.testing.expect(matrices.hdpc.get(i, kp + s + i).isOne());
    }

    // LT rows have nonzeros (at binary rows [S, L-H))
    var row: u32 = s;
    while (row < l - h) : (row += 1) {
        var nz: u32 = 0;
        var c: u32 = 0;
        while (c < l) : (c += 1) {
            if (matrices.binary.get(row, c)) nz += 1;
        }
        try std.testing.expect(nz >= 3);
    }
}
