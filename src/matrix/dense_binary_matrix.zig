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
        _ = .{ allocator, rows, cols };
        @panic("TODO");
    }

    pub fn deinit(self: DenseBinaryMatrix) void {
        self.allocator.free(self.data);
    }

    pub fn get(self: DenseBinaryMatrix, row: u32, col: u32) bool {
        _ = .{ self, row, col };
        @panic("TODO");
    }

    pub fn set(self: *DenseBinaryMatrix, row: u32, col: u32, val: bool) void {
        _ = .{ self, row, col, val };
        @panic("TODO");
    }

    pub fn swapRows(self: *DenseBinaryMatrix, i: u32, j: u32) void {
        _ = .{ self, i, j };
        @panic("TODO");
    }

    pub fn xorRow(self: *DenseBinaryMatrix, src: u32, dst: u32) void {
        _ = .{ self, src, dst };
        @panic("TODO");
    }

    pub fn numRows(self: DenseBinaryMatrix) u32 {
        return self.rows;
    }

    pub fn numCols(self: DenseBinaryMatrix) u32 {
        return self.cols;
    }
};
