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
        _ = .{ allocator, rows, cols };
        @panic("TODO");
    }

    pub fn deinit(self: *SparseBinaryMatrix) void {
        _ = self;
        @panic("TODO");
    }

    pub fn get(self: SparseBinaryMatrix, row: u32, col: u32) bool {
        _ = .{ self, row, col };
        @panic("TODO");
    }

    pub fn set(self: *SparseBinaryMatrix, row: u32, col: u32, val: bool) void {
        _ = .{ self, row, col, val };
        @panic("TODO");
    }

    pub fn swapRows(self: *SparseBinaryMatrix, i: u32, j: u32) void {
        _ = .{ self, i, j };
        @panic("TODO");
    }

    pub fn xorRow(self: *SparseBinaryMatrix, src: u32, dst: u32) void {
        _ = .{ self, src, dst };
        @panic("TODO");
    }

    pub fn toDense(self: SparseBinaryMatrix) !DenseBinaryMatrix {
        _ = self;
        @panic("TODO");
    }

    pub fn rowDensity(self: SparseBinaryMatrix, row: u32) u32 {
        _ = .{ self, row };
        @panic("TODO");
    }
};
