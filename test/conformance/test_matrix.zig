// Matrix operation conformance tests
// Verifies DenseBinaryMatrix, SparseBinaryMatrix, and OctetMatrix types
// implement correct get/set, row operations, and mutual consistency.

const std = @import("std");
const raptorq = @import("raptorq");
const DenseBinaryMatrix = raptorq.dense_binary_matrix.DenseBinaryMatrix;
const SparseBinaryMatrix = raptorq.sparse_matrix.SparseBinaryMatrix;
const OctetMatrix = raptorq.octet_matrix.OctetMatrix;
const Octet = raptorq.octet.Octet;

test "DenseBinaryMatrix get/set roundtrip" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 8, 130);
    defer m.deinit();

    // All zeros initially
    var r: u32 = 0;
    while (r < 8) : (r += 1) {
        var c: u32 = 0;
        while (c < 130) : (c += 1) {
            try std.testing.expect(!m.get(r, c));
        }
    }

    // Set and verify specific bits including cross-word boundaries
    m.set(0, 0, true);
    m.set(0, 63, true);
    m.set(0, 64, true);
    m.set(7, 129, true);
    try std.testing.expect(m.get(0, 0));
    try std.testing.expect(m.get(0, 63));
    try std.testing.expect(m.get(0, 64));
    try std.testing.expect(m.get(7, 129));
    try std.testing.expect(!m.get(0, 1));
    try std.testing.expect(!m.get(7, 128));

    // Clear and verify
    m.set(0, 0, false);
    try std.testing.expect(!m.get(0, 0));
}

test "DenseBinaryMatrix row swap" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 3, 80);
    defer m.deinit();

    m.set(0, 5, true);
    m.set(0, 70, true);
    m.set(2, 30, true);

    m.swapRows(0, 2);

    try std.testing.expect(!m.get(0, 5));
    try std.testing.expect(!m.get(0, 70));
    try std.testing.expect(m.get(0, 30));
    try std.testing.expect(m.get(2, 5));
    try std.testing.expect(m.get(2, 70));
    try std.testing.expect(!m.get(2, 30));
}

test "DenseBinaryMatrix XOR row" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 2, 80);
    defer m.deinit();

    m.set(0, 10, true);
    m.set(0, 70, true);
    m.set(1, 10, true);
    m.set(1, 50, true);

    m.xorRow(0, 1);
    // Row 1: {10,50} XOR {10,70} = {50,70} (10 cancels)
    try std.testing.expect(!m.get(1, 10));
    try std.testing.expect(m.get(1, 50));
    try std.testing.expect(m.get(1, 70));
}

test "OctetMatrix get/set roundtrip" {
    var m = try OctetMatrix.init(std.testing.allocator, 4, 5);
    defer m.deinit();

    // All zeros initially
    var r: u32 = 0;
    while (r < 4) : (r += 1) {
        var c: u32 = 0;
        while (c < 5) : (c += 1) {
            try std.testing.expect(m.get(r, c).isZero());
        }
    }

    // Set and verify
    m.set(0, 0, Octet.init(42));
    m.set(3, 4, Octet.init(255));
    try std.testing.expectEqual(@as(u8, 42), m.get(0, 0).value);
    try std.testing.expectEqual(@as(u8, 255), m.get(3, 4).value);
    try std.testing.expect(m.get(0, 1).isZero());
}

test "OctetMatrix identity" {
    var m = try OctetMatrix.identity(std.testing.allocator, 5);
    defer m.deinit();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var j: u32 = 0;
        while (j < 5) : (j += 1) {
            if (i == j) {
                try std.testing.expect(m.get(i, j).isOne());
            } else {
                try std.testing.expect(m.get(i, j).isZero());
            }
        }
    }

    try std.testing.expectEqual(@as(u32, 5), m.numRows());
    try std.testing.expectEqual(@as(u32, 5), m.numCols());
}

test "OctetMatrix row operations" {
    var m = try OctetMatrix.init(std.testing.allocator, 3, 3);
    defer m.deinit();

    // Row 0: [1, 2, 3]
    m.set(0, 0, Octet.init(1));
    m.set(0, 1, Octet.init(2));
    m.set(0, 2, Octet.init(3));
    // Row 1: [4, 5, 6]
    m.set(1, 0, Octet.init(4));
    m.set(1, 1, Octet.init(5));
    m.set(1, 2, Octet.init(6));
    // Row 2: [0, 0, 0]

    // swapRows
    m.swapRows(0, 1);
    try std.testing.expectEqual(@as(u8, 4), m.get(0, 0).value);
    try std.testing.expectEqual(@as(u8, 1), m.get(1, 0).value);
    m.swapRows(0, 1); // swap back

    // addAssignRow: row[1] += row[0] (GF-256 XOR)
    m.addAssignRow(0, 1);
    try std.testing.expectEqual(@as(u8, 1 ^ 4), m.get(1, 0).value);
    try std.testing.expectEqual(@as(u8, 2 ^ 5), m.get(1, 1).value);
    try std.testing.expectEqual(@as(u8, 3 ^ 6), m.get(1, 2).value);

    // mulAssignRow: row[2] = [10, 20, 30], then multiply by 3
    m.set(2, 0, Octet.init(10));
    m.set(2, 1, Octet.init(20));
    m.set(2, 2, Octet.init(30));
    m.mulAssignRow(2, Octet.init(3));
    try std.testing.expectEqual(Octet.init(10).mul(Octet.init(3)).value, m.get(2, 0).value);
    try std.testing.expectEqual(Octet.init(20).mul(Octet.init(3)).value, m.get(2, 1).value);
    try std.testing.expectEqual(Octet.init(30).mul(Octet.init(3)).value, m.get(2, 2).value);

    // fmaRow: row[2] += row[0] * scalar
    const before_0 = m.get(2, 0).value;
    const scalar = Octet.init(7);
    m.fmaRow(0, 2, scalar);
    try std.testing.expectEqual(
        Octet.init(before_0).add(Octet.init(1).mul(scalar)).value,
        m.get(2, 0).value,
    );
}

test "SparseBinaryMatrix consistency with DenseBinaryMatrix" {
    // Same operations on sparse and dense matrices should produce identical results
    var dense = try DenseBinaryMatrix.init(std.testing.allocator, 4, 20);
    defer dense.deinit();
    var sparse = try SparseBinaryMatrix.init(std.testing.allocator, 4, 20);
    defer sparse.deinit();

    // Set same pattern
    const positions = [_][2]u32{ .{ 0, 3 }, .{ 0, 15 }, .{ 1, 7 }, .{ 1, 15 }, .{ 2, 0 }, .{ 3, 19 } };
    for (positions) |pos| {
        dense.set(pos[0], pos[1], true);
        try sparse.set(pos[0], pos[1], true);
    }

    // Verify same contents
    var r: u32 = 0;
    while (r < 4) : (r += 1) {
        var c: u32 = 0;
        while (c < 20) : (c += 1) {
            try std.testing.expectEqual(dense.get(r, c), sparse.get(r, c));
        }
    }

    // Row swap on both
    dense.swapRows(0, 2);
    sparse.swapRows(0, 2);
    r = 0;
    while (r < 4) : (r += 1) {
        var c: u32 = 0;
        while (c < 20) : (c += 1) {
            try std.testing.expectEqual(dense.get(r, c), sparse.get(r, c));
        }
    }

    // XOR row on both
    dense.xorRow(0, 1);
    try sparse.xorRow(0, 1);
    r = 0;
    while (r < 4) : (r += 1) {
        var c: u32 = 0;
        while (c < 20) : (c += 1) {
            try std.testing.expectEqual(dense.get(r, c), sparse.get(r, c));
        }
    }
}

test "SparseBinaryMatrix to dense conversion" {
    var sparse = try SparseBinaryMatrix.init(std.testing.allocator, 3, 30);
    defer sparse.deinit();

    try sparse.set(0, 5, true);
    try sparse.set(0, 25, true);
    try sparse.set(1, 0, true);
    try sparse.set(2, 29, true);

    var dense = try sparse.toDense();
    defer dense.deinit();

    try std.testing.expect(dense.get(0, 5));
    try std.testing.expect(dense.get(0, 25));
    try std.testing.expect(dense.get(1, 0));
    try std.testing.expect(dense.get(2, 29));

    // Check a few zeros
    try std.testing.expect(!dense.get(0, 0));
    try std.testing.expect(!dense.get(1, 5));
    try std.testing.expect(!dense.get(2, 0));

    // Row density
    try std.testing.expectEqual(@as(u32, 2), sparse.rowDensity(0));
    try std.testing.expectEqual(@as(u32, 1), sparse.rowDensity(1));
    try std.testing.expectEqual(@as(u32, 1), sparse.rowDensity(2));
}
