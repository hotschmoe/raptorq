// Hybrid sparse/dense binary matrix

const std = @import("std");
const SparseBinaryVec = @import("../util/sparse_vec.zig").SparseBinaryVec;
const DenseBinaryMatrix = @import("dense_binary_matrix.zig").DenseBinaryMatrix;

pub const SparseBinaryMatrix = struct {
    rows: u32,
    cols: u32,
    sparse_rows: []SparseBinaryVec,
    dense_threshold: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !SparseBinaryMatrix {
        const sparse_rows = try allocator.alloc(SparseBinaryVec, rows);
        for (sparse_rows) |*row| {
            row.* = SparseBinaryVec.init(allocator);
        }
        return .{
            .rows = rows,
            .cols = cols,
            .sparse_rows = sparse_rows,
            .dense_threshold = cols / 2,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SparseBinaryMatrix) void {
        for (self.sparse_rows) |*row| {
            row.deinit();
        }
        self.allocator.free(self.sparse_rows);
    }

    pub fn get(self: SparseBinaryMatrix, row: u32, col: u32) bool {
        return self.sparse_rows[row].get(col);
    }

    pub fn set(self: *SparseBinaryMatrix, row: u32, col: u32, val: bool) !void {
        if (val) {
            try self.sparse_rows[row].set(col);
        } else {
            self.sparse_rows[row].unset(col);
        }
    }

    pub fn swapRows(self: *SparseBinaryMatrix, i: u32, j: u32) void {
        if (i == j) return;
        std.mem.swap(SparseBinaryVec, &self.sparse_rows[i], &self.sparse_rows[j]);
    }

    pub fn xorRow(self: *SparseBinaryMatrix, src: u32, dst: u32) !void {
        try self.sparse_rows[dst].xorWith(self.sparse_rows[src]);
    }

    pub fn toDense(self: SparseBinaryMatrix) !DenseBinaryMatrix {
        var dense = try DenseBinaryMatrix.init(self.allocator, self.rows, self.cols);
        var row: u32 = 0;
        while (row < self.rows) : (row += 1) {
            for (self.sparse_rows[row].indices.items) |col| {
                dense.set(row, col, true);
            }
        }
        return dense;
    }

    pub fn rowDensity(self: SparseBinaryMatrix, row: u32) u32 {
        return @intCast(self.sparse_rows[row].count());
    }
};

test "SparseBinaryMatrix get/set" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 3, 10);
    defer m.deinit();

    try std.testing.expect(!m.get(0, 0));
    try m.set(0, 0, true);
    try std.testing.expect(m.get(0, 0));

    try m.set(2, 9, true);
    try std.testing.expect(m.get(2, 9));

    try m.set(0, 0, false);
    try std.testing.expect(!m.get(0, 0));
}

test "SparseBinaryMatrix swapRows" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10);
    defer m.deinit();

    try m.set(0, 1, true);
    try m.set(0, 5, true);
    try m.set(1, 3, true);

    m.swapRows(0, 1);
    try std.testing.expect(!m.get(0, 1));
    try std.testing.expect(!m.get(0, 5));
    try std.testing.expect(m.get(0, 3));
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(m.get(1, 5));
}

test "SparseBinaryMatrix xorRow" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10);
    defer m.deinit();

    try m.set(0, 1, true);
    try m.set(0, 3, true);
    try m.set(1, 3, true);
    try m.set(1, 5, true);

    try m.xorRow(0, 1);
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(!m.get(1, 3));
    try std.testing.expect(m.get(1, 5));
}

test "SparseBinaryMatrix toDense" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10);
    defer m.deinit();

    try m.set(0, 2, true);
    try m.set(1, 7, true);

    var d = try m.toDense();
    defer d.deinit();

    try std.testing.expect(d.get(0, 2));
    try std.testing.expect(!d.get(0, 7));
    try std.testing.expect(!d.get(1, 2));
    try std.testing.expect(d.get(1, 7));
}

test "SparseBinaryMatrix rowDensity" {
    var m = try SparseBinaryMatrix.init(std.testing.allocator, 2, 10);
    defer m.deinit();

    try std.testing.expectEqual(@as(u32, 0), m.rowDensity(0));
    try m.set(0, 1, true);
    try m.set(0, 5, true);
    try m.set(0, 8, true);
    try std.testing.expectEqual(@as(u32, 3), m.rowDensity(0));
}
