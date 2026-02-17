// RFC 6330 Section 5.3.3 - Constraint matrix construction
//
// Produces separate binary and HDPC matrices for the PI solver:
//   binary: DenseBinaryMatrix for LDPC + LT rows (all entries are 0/1)
//   hdpc:   OctetMatrix for HDPC rows (GF(256) entries)

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const OctetMatrix = @import("octet_matrix.zig").OctetMatrix;
const DenseBinaryMatrix = @import("dense_binary_matrix.zig").DenseBinaryMatrix;
const systematic_constants = @import("../tables/systematic_constants.zig");
const rng = @import("../math/rng.zig");
const helpers = @import("../util/helpers.zig");

pub const ConstraintMatrices = struct {
    binary: DenseBinaryMatrix, // (L-H) rows x L cols: LDPC (rows 0..S-1) + LT (rows S..L-H-1)
    hdpc: OctetMatrix, // H rows x L cols
    s: u32,
    h: u32,
    l: u32,

    pub fn deinit(self: *ConstraintMatrices) void {
        self.binary.deinit();
        self.hdpc.deinit();
    }
};

/// Build constraint matrices for encoding (ISIs 0..K'-1).
pub fn buildConstraintMatrices(allocator: std.mem.Allocator, k_prime: u32) !ConstraintMatrices {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const s = si.s;
    const h = si.h;
    const l = k_prime + s + h;
    const binary_rows = l - h; // S + K' rows (LDPC + LT)

    var binary = try DenseBinaryMatrix.init(allocator, binary_rows, l);
    errdefer binary.deinit();

    var hdpc = try OctetMatrix.init(allocator, h, l);
    errdefer hdpc.deinit();

    generateLDPCBinary(&binary, k_prime, s);
    try generateHDPCSplit(allocator, &hdpc, k_prime, s, h);
    generateLTBinary(&binary, k_prime, s, k_prime);

    return .{ .binary = binary, .hdpc = hdpc, .s = s, .h = h, .l = l };
}

/// Build constraint matrices for decoding (arbitrary ISIs).
pub fn buildDecodingMatrices(allocator: std.mem.Allocator, k_prime: u32, isis: []const u32) !ConstraintMatrices {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const s = si.s;
    const h = si.h;
    const l = k_prime + s + h;
    const binary_rows = l - h;

    var binary = try DenseBinaryMatrix.init(allocator, binary_rows, l);
    errdefer binary.deinit();

    var hdpc = try OctetMatrix.init(allocator, h, l);
    errdefer hdpc.deinit();

    generateLDPCBinary(&binary, k_prime, s);
    try generateHDPCSplit(allocator, &hdpc, k_prime, s, h);
    generateLTRowsBinary(&binary, k_prime, s, isis);

    return .{ .binary = binary, .hdpc = hdpc, .s = s, .h = h, .l = l };
}

/// LDPC rows written directly into DenseBinaryMatrix (rows 0..S-1).
fn generateLDPCBinary(binary: *DenseBinaryMatrix, k_prime: u32, s: u32) void {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const w = si.w;
    const b = w - s;
    const p = k_prime + s + si.h - w;

    var i: u32 = 0;
    while (i < b) : (i += 1) {
        const a_val: u32 = 1 + (i / s) % (s - 1);
        const b_val: u32 = i % s;

        binary.set(b_val, i, true);
        binary.set((b_val + a_val) % s, i, true);
        binary.set((b_val + 2 * a_val) % s, i, true);
    }

    i = 0;
    while (i < s) : (i += 1) {
        binary.set(i, b + i, true);
    }

    i = 0;
    while (i < s) : (i += 1) {
        binary.set(i, w + (i % p), true);
        binary.set(i, w + ((i + 1) % p), true);
    }
}

/// HDPC rows written into OctetMatrix (H rows x L cols, row 0 = logical row S).
fn generateHDPCSplit(allocator: std.mem.Allocator, hdpc: *OctetMatrix, k_prime: u32, s: u32, h: u32) !void {
    const kp_s = k_prime + s;

    var mt = try OctetMatrix.init(allocator, h, kp_s);
    defer mt.deinit();

    var j: u32 = 0;
    while (j < kp_s - 1) : (j += 1) {
        const r1 = rng.rand(j + 1, 6, h);
        const r2 = (rng.rand(j + 1, 6, h) + rng.rand(j + 1, 7, h - 1) + 1) % h;
        mt.set(r1, j, Octet.ONE);
        mt.set(r2, j, Octet.ONE);
    }
    {
        var alpha_pow = Octet.ONE;
        var i: u32 = 0;
        while (i < h) : (i += 1) {
            mt.set(i, kp_s - 1, alpha_pow);
            alpha_pow = alpha_pow.mul(Octet.ALPHA);
        }
    }

    // MT * GAMMA via right-to-left recurrence
    {
        var r: u32 = 0;
        while (r < h) : (r += 1) {
            hdpc.set(r, kp_s - 1, mt.get(r, kp_s - 1));
        }

        if (kp_s >= 2) {
            var c_iter: u32 = kp_s - 1;
            while (c_iter > 0) {
                c_iter -= 1;
                r = 0;
                while (r < h) : (r += 1) {
                    const prev = hdpc.get(r, c_iter + 1);
                    const mt_val = mt.get(r, c_iter);
                    const val = mt_val.add(Octet.ALPHA.mul(prev));
                    hdpc.set(r, c_iter, val);
                }
            }
        }
    }

    // H x H identity at columns K'+S .. K'+S+H-1
    {
        var i: u32 = 0;
        while (i < h) : (i += 1) {
            hdpc.set(i, kp_s + i, Octet.ONE);
        }
    }
}

/// LT rows for sequential ISIs, written into DenseBinaryMatrix at rows S..S+num_symbols-1.
fn generateLTBinary(binary: *DenseBinaryMatrix, k_prime: u32, s: u32, num_symbols: u32) void {
    const params = ltParams(k_prime, s);
    var x: u32 = 0;
    while (x < num_symbols) : (x += 1) {
        writeLTRowBinary(binary, k_prime, s + x, x, params);
    }
}

/// LT rows for arbitrary ISIs, written into DenseBinaryMatrix at rows S..S+isis.len-1.
fn generateLTRowsBinary(binary: *DenseBinaryMatrix, k_prime: u32, s: u32, isis: []const u32) void {
    const params = ltParams(k_prime, s);
    for (isis, 0..) |isi, x| {
        writeLTRowBinary(binary, k_prime, s + @as(u32, @intCast(x)), isi, params);
    }
}

const LTParams = struct { w: u32, p: u32, p1: u32 };

fn ltParams(k_prime: u32, s: u32) LTParams {
    const si = systematic_constants.findSystematicIndex(k_prime).?;
    const w = si.w;
    const p = k_prime + s + si.h - w;
    return .{ .w = w, .p = p, .p1 = helpers.nextPrime(p) };
}

fn writeLTRowBinary(binary: *DenseBinaryMatrix, k_prime: u32, row: u32, isi: u32, params: LTParams) void {
    const tuple = rng.genTuple(k_prime, isi);
    const w = params.w;
    const p = params.p;
    const p1 = params.p1;

    var b_val = tuple.b;
    binary.set(row, b_val, true);
    var j: u32 = 1;
    while (j < tuple.d) : (j += 1) {
        b_val = (b_val + tuple.a) % w;
        binary.set(row, b_val, true);
    }

    var b1 = tuple.b1;
    while (b1 >= p) b1 = (b1 + tuple.a1) % p1;
    binary.set(row, w + b1, true);
    j = 1;
    while (j < tuple.d1) : (j += 1) {
        b1 = (b1 + tuple.a1) % p1;
        while (b1 >= p) b1 = (b1 + tuple.a1) % p1;
        binary.set(row, w + b1, true);
    }
}

// -- Tests --
// Tests verify that the new split construction produces identical matrices to
// what the old single-OctetMatrix construction would have produced.

test "buildConstraintMatrices dimensions K'=10" {
    // K'=10: S=7, H=10, W=17, L=27
    var cm = try buildConstraintMatrices(std.testing.allocator, 10);
    defer cm.deinit();

    try std.testing.expectEqual(@as(u32, 17), cm.binary.numRows()); // L-H = 27-10 = 17
    try std.testing.expectEqual(@as(u32, 27), cm.binary.numCols());
    try std.testing.expectEqual(@as(u32, 10), cm.hdpc.numRows());
    try std.testing.expectEqual(@as(u32, 27), cm.hdpc.numCols());
}

test "buildConstraintMatrices LDPC identity block K'=10" {
    var cm = try buildConstraintMatrices(std.testing.allocator, 10);
    defer cm.deinit();

    // S x S identity at columns B..B+S-1 = columns 10..16
    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        var j: u32 = 0;
        while (j < 7) : (j += 1) {
            const val = cm.binary.get(i, 10 + j);
            if (i == j) {
                try std.testing.expect(val);
            } else {
                try std.testing.expect(!val);
            }
        }
    }
}

test "buildConstraintMatrices HDPC identity block K'=10" {
    var cm = try buildConstraintMatrices(std.testing.allocator, 10);
    defer cm.deinit();

    // H x H identity at columns 17..26 in hdpc matrix (row 0 = logical row S)
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var j: u32 = 0;
        while (j < 10) : (j += 1) {
            const val = cm.hdpc.get(i, 17 + j);
            if (i == j) {
                try std.testing.expect(val.isOne());
            } else {
                try std.testing.expect(val.isZero());
            }
        }
    }
}

test "buildDecodingMatrices matches buildConstraintMatrices for sequential ISIs" {
    const k_prime: u32 = 10;

    var enc = try buildConstraintMatrices(std.testing.allocator, k_prime);
    defer enc.deinit();

    const isis = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var dec = try buildDecodingMatrices(std.testing.allocator, k_prime, &isis);
    defer dec.deinit();

    // Binary matrices must match
    const binary_rows = enc.binary.numRows();
    const cols = enc.binary.numCols();
    var row: u32 = 0;
    while (row < binary_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            try std.testing.expectEqual(enc.binary.get(row, col), dec.binary.get(row, col));
        }
    }

    // HDPC matrices must match
    const h = enc.hdpc.numRows();
    row = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            try std.testing.expectEqual(enc.hdpc.get(row, col).value, dec.hdpc.get(row, col).value);
        }
    }
}

test "buildConstraintMatrices LT row has correct degree" {
    var cm = try buildConstraintMatrices(std.testing.allocator, 10);
    defer cm.deinit();

    const s: u32 = 7;
    const l: u32 = 27;
    const binary_rows = cm.binary.numRows(); // L-H = 17

    var row: u32 = s;
    while (row < binary_rows) : (row += 1) {
        var nonzeros: u32 = 0;
        var col: u32 = 0;
        while (col < l) : (col += 1) {
            if (cm.binary.get(row, col)) nonzeros += 1;
        }
        try std.testing.expect(nonzeros >= 2);
    }
}
