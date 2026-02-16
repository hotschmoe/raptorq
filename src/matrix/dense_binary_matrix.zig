// Bit-packed binary matrix using u64 words

const std = @import("std");
const gf2 = @import("../math/gf2.zig");

pub const DenseBinaryMatrix = struct {
    rows: u32,
    cols: u32,
    words_per_row: u32,
    data: []u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !DenseBinaryMatrix {
        const words_per_row = (cols + 63) / 64;
        const total = @as(usize, rows) * @as(usize, words_per_row);
        const data = try allocator.alloc(u64, total);
        @memset(data, 0);
        return .{
            .rows = rows,
            .cols = cols,
            .words_per_row = words_per_row,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: DenseBinaryMatrix) void {
        self.allocator.free(self.data);
    }

    fn rowSlice(self: DenseBinaryMatrix, row: u32) []u64 {
        const off = @as(usize, row) * @as(usize, self.words_per_row);
        return self.data[off..][0..self.words_per_row];
    }

    fn rowSliceConst(self: DenseBinaryMatrix, row: u32) []const u64 {
        const off = @as(usize, row) * @as(usize, self.words_per_row);
        return self.data[off..][0..self.words_per_row];
    }

    pub fn get(self: DenseBinaryMatrix, row: u32, col: u32) bool {
        return gf2.getBit(self.rowSliceConst(row), col);
    }

    pub fn set(self: *DenseBinaryMatrix, row: u32, col: u32, val: bool) void {
        gf2.setBit(self.rowSlice(row), col, val);
    }

    pub fn swapRows(self: *DenseBinaryMatrix, i: u32, j: u32) void {
        if (i == j) return;
        const row_i = self.rowSlice(i);
        const row_j = self.rowSlice(j);
        for (row_i, row_j) |*a, *b| {
            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;
        }
    }

    pub fn xorRow(self: *DenseBinaryMatrix, src: u32, dst: u32) void {
        gf2.xorSlice(self.rowSlice(dst), self.rowSliceConst(src));
    }

    pub fn numRows(self: DenseBinaryMatrix) u32 {
        return self.rows;
    }

    pub fn numCols(self: DenseBinaryMatrix) u32 {
        return self.cols;
    }
};

test "DenseBinaryMatrix get/set" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 4, 100);
    defer m.deinit();

    try std.testing.expect(!m.get(0, 0));
    m.set(0, 0, true);
    try std.testing.expect(m.get(0, 0));

    m.set(2, 99, true);
    try std.testing.expect(m.get(2, 99));
    try std.testing.expect(!m.get(2, 98));

    m.set(0, 0, false);
    try std.testing.expect(!m.get(0, 0));
}

test "DenseBinaryMatrix swapRows" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 3, 10);
    defer m.deinit();

    m.set(0, 1, true);
    m.set(0, 5, true);
    m.set(1, 3, true);

    m.swapRows(0, 1);
    try std.testing.expect(!m.get(0, 1));
    try std.testing.expect(!m.get(0, 5));
    try std.testing.expect(m.get(0, 3));
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(m.get(1, 5));
}

test "DenseBinaryMatrix xorRow" {
    var m = try DenseBinaryMatrix.init(std.testing.allocator, 2, 10);
    defer m.deinit();

    m.set(0, 1, true);
    m.set(0, 3, true);
    m.set(1, 3, true);
    m.set(1, 5, true);

    m.xorRow(0, 1);
    // dst row 1: was {3,5}, XOR {1,3} = {1,5}
    try std.testing.expect(m.get(1, 1));
    try std.testing.expect(!m.get(1, 3));
    try std.testing.expect(m.get(1, 5));
}
