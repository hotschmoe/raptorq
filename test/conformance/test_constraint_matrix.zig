// RFC 6330 Section 5.3.3 - Constraint matrix construction conformance tests
// Verifies LDPC, HDPC, and LT sub-matrix structure within the constraint
// matrix A for multiple K' values.

const std = @import("std");
const raptorq = @import("raptorq");
const OctetMatrix = raptorq.octet_matrix.OctetMatrix;
const Octet = raptorq.octet.Octet;
const cm = raptorq.constraint_matrix;
const sc = raptorq.systematic_constants;
const helpers = raptorq.helpers;

test "Constraint matrix dimensions" {
    // A is L x L where L = K' + S + H for every valid K'
    const k_values = [_]u32{ 10, 18, 46, 101, 500, 1000 };

    for (k_values) |k| {
        const kp = sc.ceilKPrime(k);
        const si = sc.findSystematicIndex(kp).?;
        const l = kp + si.s + si.h;

        var m = try cm.buildConstraintMatrix(std.testing.allocator, kp);
        defer m.deinit();

        try std.testing.expectEqual(l, m.numRows());
        try std.testing.expectEqual(l, m.numCols());
    }
}

test "LDPC sub-matrix structure" {
    // RFC 6330 Section 5.3.3.3: first S rows
    // Structure: circulant pattern over first B=W-S columns, S x S identity at columns B..B+S-1,
    // PI circulant at columns W..W+P-1
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s = si.s; // 7
    const w = si.w; // 17
    const b = w - s; // 10
    const l = kp + si.s + si.h; // 27
    const p = l - w; // 10

    var m = try cm.buildConstraintMatrix(std.testing.allocator, kp);
    defer m.deinit();

    // S x S identity block at columns B..B+S-1
    var i: u32 = 0;
    while (i < s) : (i += 1) {
        var j: u32 = 0;
        while (j < s) : (j += 1) {
            if (i == j) {
                try std.testing.expect(m.get(i, b + j).isOne());
            } else {
                try std.testing.expect(m.get(i, b + j).isZero());
            }
        }
    }

    // Each LDPC row has nonzeros in columns 0..B-1 (circulant contributions
    // from multiple source columns mapping to the same row via modular arithmetic),
    // plus 1 from identity, plus 1-2 from PI circulant.
    i = 0;
    while (i < s) : (i += 1) {
        var circulant_nz: u32 = 0;
        var c: u32 = 0;
        while (c < b) : (c += 1) {
            if (!m.get(i, c).isZero()) circulant_nz += 1;
        }
        // Each column contributes 3 nonzeros across all S rows.
        // Per-row count depends on B and S; must have at least 1.
        try std.testing.expect(circulant_nz >= 1);

        // PI circulant: 1-2 nonzeros in columns W..W+P-1
        var pi_nz: u32 = 0;
        c = w;
        while (c < w + p) : (c += 1) {
            if (!m.get(i, c).isZero()) pi_nz += 1;
        }
        try std.testing.expect(pi_nz >= 1 and pi_nz <= 2);
    }
}

test "HDPC sub-matrix rows" {
    // RFC 6330 Section 5.3.3.3: rows S..S+H-1
    // H x H identity block at columns K'+S..K'+S+H-1
    const kp: u32 = 10;
    const si = sc.findSystematicIndex(kp).?;
    const s = si.s; // 7
    const h = si.h; // 10
    const kp_s = kp + s; // 17

    var m = try cm.buildConstraintMatrix(std.testing.allocator, kp);
    defer m.deinit();

    // H x H identity block
    var i: u32 = 0;
    while (i < h) : (i += 1) {
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            if (i == j) {
                try std.testing.expect(m.get(s + i, kp_s + j).isOne());
            } else {
                try std.testing.expect(m.get(s + i, kp_s + j).isZero());
            }
        }
    }

    // HDPC rows should have nonzeros in columns 0..K'+S-1 (from MT*GAMMA)
    i = 0;
    while (i < h) : (i += 1) {
        var has_nonzero = false;
        var c: u32 = 0;
        while (c < kp_s) : (c += 1) {
            if (!m.get(s + i, c).isZero()) {
                has_nonzero = true;
                break;
            }
        }
        try std.testing.expect(has_nonzero);
    }
}

test "Identity block in constraint matrix" {
    // LT rows (S+H..L-1): each row has nonzeros determined by tuple generation.
    // At minimum, each LT row has d >= 1 (LT) + d1 >= 2 (PI) nonzero entries.
    const kp: u32 = 26;
    const si = sc.findSystematicIndex(kp).?;
    const s = si.s;
    const h = si.h;
    const l = kp + s + h;

    var m = try cm.buildConstraintMatrix(std.testing.allocator, kp);
    defer m.deinit();

    var row: u32 = s + h;
    while (row < l) : (row += 1) {
        var nz: u32 = 0;
        var c: u32 = 0;
        while (c < l) : (c += 1) {
            if (!m.get(row, c).isZero()) nz += 1;
        }
        // d >= 1 from LT component, d1 >= 2 from PI component
        try std.testing.expect(nz >= 3);
    }
}

test "Constraint matrix for K'=10" {
    // Encoding matrix with ISIs 0..K'-1 equals the standard constraint matrix
    const kp: u32 = 10;
    const l = sc.numIntermediateSymbols(kp);

    var encoding = try cm.buildConstraintMatrix(std.testing.allocator, kp);
    defer encoding.deinit();

    var isis: [10]u32 = undefined;
    for (&isis, 0..) |*v, i| v.* = @intCast(i);
    var decoding = try cm.buildDecodingMatrix(std.testing.allocator, kp, &isis);
    defer decoding.deinit();

    // Both matrices must be identical
    var r: u32 = 0;
    while (r < l) : (r += 1) {
        var c: u32 = 0;
        while (c < l) : (c += 1) {
            try std.testing.expectEqual(encoding.get(r, c).value, decoding.get(r, c).value);
        }
    }
}

test "Constraint matrix for K'=100" {
    // Verify structural properties for a medium-sized K'
    // K'=101 is the closest valid entry (K'=100 is not in Table 2)
    const kp: u32 = 101;
    const si = sc.findSystematicIndex(kp).?;
    const s = si.s;
    const h = si.h;
    const l = kp + s + h;

    var m = try cm.buildConstraintMatrix(std.testing.allocator, kp);
    defer m.deinit();

    try std.testing.expectEqual(l, m.numRows());
    try std.testing.expectEqual(l, m.numCols());

    // LDPC S x S identity block
    const b = si.w - s;
    var i: u32 = 0;
    while (i < s) : (i += 1) {
        try std.testing.expect(m.get(i, b + i).isOne());
    }

    // HDPC H x H identity block
    i = 0;
    while (i < h) : (i += 1) {
        try std.testing.expect(m.get(s + i, kp + s + i).isOne());
    }

    // LT rows have nonzeros
    var row: u32 = s + h;
    while (row < l) : (row += 1) {
        var nz: u32 = 0;
        var c: u32 = 0;
        while (c < l) : (c += 1) {
            if (!m.get(row, c).isZero()) nz += 1;
        }
        try std.testing.expect(nz >= 3);
    }
}
