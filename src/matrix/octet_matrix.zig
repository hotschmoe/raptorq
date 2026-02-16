// Dense matrix over GF(256) octets

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const octets_mod = @import("../math/octets.zig");

pub const OctetMatrix = struct {
    rows: u32,
    cols: u32,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !OctetMatrix {
        _ = .{ allocator, rows, cols };
        @panic("TODO");
    }

    pub fn identity(allocator: std.mem.Allocator, size: u32) !OctetMatrix {
        _ = .{ allocator, size };
        @panic("TODO");
    }

    pub fn deinit(self: OctetMatrix) void {
        self.allocator.free(self.data);
    }

    pub fn get(self: OctetMatrix, row: u32, col: u32) Octet {
        _ = .{ self, row, col };
        @panic("TODO");
    }

    pub fn set(self: *OctetMatrix, row: u32, col: u32, val: Octet) void {
        _ = .{ self, row, col, val };
        @panic("TODO");
    }

    pub fn swapRows(self: *OctetMatrix, i: u32, j: u32) void {
        _ = .{ self, i, j };
        @panic("TODO");
    }

    pub fn addAssignRow(self: *OctetMatrix, src: u32, dst: u32) void {
        _ = .{ self, src, dst };
        @panic("TODO");
    }

    pub fn fmaRow(self: *OctetMatrix, src: u32, dst: u32, scalar: Octet) void {
        _ = .{ self, src, dst, scalar };
        @panic("TODO");
    }

    pub fn mulAssignRow(self: *OctetMatrix, row: u32, scalar: Octet) void {
        _ = .{ self, row, scalar };
        @panic("TODO");
    }

    pub fn numRows(self: OctetMatrix) u32 {
        return self.rows;
    }

    pub fn numCols(self: OctetMatrix) u32 {
        return self.cols;
    }
};
