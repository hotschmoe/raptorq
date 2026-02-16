// RFC 6330 Section 5.3.3 - Constraint matrix construction

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("octet_matrix.zig").OctetMatrix;
const SparseBinaryMatrix = @import("sparse_matrix.zig").SparseBinaryMatrix;
const systematic_constants = @import("../tables/systematic_constants.zig");
const rng = @import("../math/rng.zig");
const helpers = @import("../util/helpers.zig");

/// Build the constraint matrix A for a given K' (RFC 6330 Section 5.3.3.3).
/// A has L rows and L columns where L = K' + S + H.
pub fn buildConstraintMatrix(allocator: std.mem.Allocator, k_prime: u32) !OctetMatrix {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const s = si.s;
    const h = si.h;
    const l = k_prime + s + h;

    var matrix = try OctetMatrix.init(allocator, l, l);

    generateLDPC(&matrix, k_prime, s);
    try generateHDPC(allocator, &matrix, k_prime, s, h);
    generateLT(&matrix, k_prime, s, h, k_prime);

    return matrix;
}

/// Generate LDPC rows of constraint matrix (RFC 6330 Section 5.3.3.3, first part).
/// Fills rows 0..S-1.
pub fn generateLDPC(matrix: *OctetMatrix, k_prime: u32, s: u32) void {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const w = si.w;
    const b = w - s;
    const p = k_prime + s + si.h - w;

    // Sub-part 1: LDPC circulant (B columns, S rows)
    // For i = 0..B-1: set 3 positions per column
    var i: u32 = 0;
    while (i < b) : (i += 1) {
        const a_val: u32 = 1 + (i / s) % (s - 1);
        const b_val: u32 = i % s;

        matrix.set(b_val, i, Octet.ONE);
        matrix.set((b_val + a_val) % s, i, Octet.ONE);
        matrix.set((b_val + 2 * a_val) % s, i, Octet.ONE);
    }

    // Sub-part 2: S x S identity at columns B..B+S-1
    i = 0;
    while (i < s) : (i += 1) {
        matrix.set(i, b + i, Octet.ONE);
    }

    // Sub-part 3: PI circulant in LDPC section
    // For i = 0..S-1: two entries per row at columns W + (i%P) and W + ((i+1)%P)
    i = 0;
    while (i < s) : (i += 1) {
        matrix.set(i, w + (i % p), Octet.ONE);
        matrix.set(i, w + ((i + 1) % p), Octet.ONE);
    }
}

/// Generate HDPC rows of constraint matrix (RFC 6330 Section 5.3.3.3, second part).
/// Fills rows S..S+H-1.
pub fn generateHDPC(allocator: std.mem.Allocator, matrix: *OctetMatrix, k_prime: u32, s: u32, h: u32) !void {
    const kp_s = k_prime + s;

    // Build MT: H x (K'+S) matrix
    // MT[rand(j+1,6,H)][j] = 1 for j=0..K'+S-2
    // MT[(rand(j+1,6,H)+rand(j+1,7,H-1)+1)%H][j] = 1 for j=0..K'+S-2
    // Last column (j=K'+S-1): MT[i][K'+S-1] = alpha^i for i=0..H-1
    var mt = try OctetMatrix.init(allocator, h, kp_s);
    defer mt.deinit();

    var j: u32 = 0;
    while (j < kp_s - 1) : (j += 1) {
        const r1 = rng.rand(j + 1, 6, h);
        const r2 = (rng.rand(j + 1, 6, h) + rng.rand(j + 1, 7, h - 1) + 1) % h;
        mt.set(r1, j, Octet.ONE);
        mt.set(r2, j, Octet.ONE);
    }
    // Last column: MT[i][K'+S-1] = alpha^i
    {
        var alpha_pow = Octet.ONE;
        var i: u32 = 0;
        while (i < h) : (i += 1) {
            mt.set(i, kp_s - 1, alpha_pow);
            alpha_pow = alpha_pow.mul(Octet.ALPHA);
        }
    }

    // Compute result = MT * GAMMA using right-to-left recurrence.
    // GAMMA is (K'+S) x (K'+S) upper-triangular where GAMMA[i][j] = alpha^(i-j) for j>=i.
    // R[r][c] = sum over k of MT[r][k] * GAMMA[k][c]
    // Using recurrence: for each row r and column c (right to left):
    //   result[r][c] = MT[r][c] + alpha * result[r][c+1]
    // This works because GAMMA[c][c]=1 and GAMMA[k][c] = alpha * GAMMA[k][c+1] for k<=c.

    // Process column by column from right to left
    // Start from column kp_s-1 where result[r][kp_s-1] = MT[r][kp_s-1]
    // Then for c = kp_s-2 downto 0: result[r][c] = MT[r][c] + alpha * result[r][c+1]

    // We write directly into the constraint matrix rows S..S+H-1, columns 0..K'+S-1
    {
        // Initialize last column
        var r: u32 = 0;
        while (r < h) : (r += 1) {
            matrix.set(s + r, kp_s - 1, mt.get(r, kp_s - 1));
        }

        // Right-to-left recurrence
        if (kp_s >= 2) {
            var c_iter: u32 = kp_s - 1;
            while (c_iter > 0) {
                c_iter -= 1;
                r = 0;
                while (r < h) : (r += 1) {
                    const prev = matrix.get(s + r, c_iter + 1);
                    const mt_val = mt.get(r, c_iter);
                    const val = mt_val.add(Octet.ALPHA.mul(prev));
                    matrix.set(s + r, c_iter, val);
                }
            }
        }
    }

    // HDPC identity block: H x H identity at columns K'+S..K'+S+H-1
    {
        var i: u32 = 0;
        while (i < h) : (i += 1) {
            matrix.set(s + i, kp_s + i, Octet.ONE);
        }
    }
}

/// Generate LT rows (encoding relationships) in the constraint matrix.
/// Fills rows S+H..S+H+num_symbols-1 (i.e., the last K' rows for source symbols).
pub fn generateLT(matrix: *OctetMatrix, k_prime: u32, s: u32, h: u32, num_symbols: u32) void {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const w = si.w;
    const l = k_prime + s + h;
    const p = l - w;
    const p1 = helpers.nextPrime(p);

    var x: u32 = 0;
    while (x < num_symbols) : (x += 1) {
        const tuple = rng.genTuple(k_prime, x);
        const row = s + h + x;

        // LT part: d entries in columns [0..W)
        var b_val = tuple.b;
        matrix.set(row, b_val, Octet.ONE);
        var j: u32 = 1;
        while (j < tuple.d) : (j += 1) {
            b_val = (b_val + tuple.a) % w;
            matrix.set(row, b_val, Octet.ONE);
        }

        // PI part: d1 entries in columns [W..W+P)
        var b1 = tuple.b1;
        while (b1 >= p) {
            b1 = (b1 + tuple.a1) % p1;
        }
        matrix.set(row, w + b1, Octet.ONE);
        j = 1;
        while (j < tuple.d1) : (j += 1) {
            b1 = (b1 + tuple.a1) % p1;
            while (b1 >= p) {
                b1 = (b1 + tuple.a1) % p1;
            }
            matrix.set(row, w + b1, Octet.ONE);
        }
    }
}

test "buildConstraintMatrix dimensions K'=10" {
    // K'=10: S=7, H=10, W=17, L=27
    var m = try buildConstraintMatrix(std.testing.allocator, 10);
    defer m.deinit();

    try std.testing.expectEqual(@as(u32, 27), m.numRows());
    try std.testing.expectEqual(@as(u32, 27), m.numCols());
}

test "buildConstraintMatrix LDPC identity block K'=10" {
    // K'=10: S=7, H=10, W=17, B=W-S=10
    // S x S identity at columns B..B+S-1 = columns 10..16
    var m = try buildConstraintMatrix(std.testing.allocator, 10);
    defer m.deinit();

    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        var j: u32 = 0;
        while (j < 7) : (j += 1) {
            const val = m.get(i, 10 + j);
            if (i == j) {
                try std.testing.expect(val.isOne());
            } else {
                try std.testing.expect(val.isZero());
            }
        }
    }
}

test "buildConstraintMatrix HDPC identity block K'=10" {
    // K'=10: S=7, H=10, K'+S=17
    // H x H identity at columns 17..26, rows 7..16
    var m = try buildConstraintMatrix(std.testing.allocator, 10);
    defer m.deinit();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var j: u32 = 0;
        while (j < 10) : (j += 1) {
            const val = m.get(7 + i, 17 + j);
            if (i == j) {
                try std.testing.expect(val.isOne());
            } else {
                try std.testing.expect(val.isZero());
            }
        }
    }
}

test "buildConstraintMatrix LT row has correct degree" {
    // Verify that each LT row (rows S+H..L-1) has at least 2 nonzero entries
    // (d >= 1 for LT part plus d1 >= 2 for PI part)
    var m = try buildConstraintMatrix(std.testing.allocator, 10);
    defer m.deinit();

    const s: u32 = 7;
    const h: u32 = 10;
    const l: u32 = 27;

    var row: u32 = s + h;
    while (row < l) : (row += 1) {
        var nonzeros: u32 = 0;
        var col: u32 = 0;
        while (col < l) : (col += 1) {
            if (!m.get(row, col).isZero()) nonzeros += 1;
        }
        try std.testing.expect(nonzeros >= 2);
    }
}
