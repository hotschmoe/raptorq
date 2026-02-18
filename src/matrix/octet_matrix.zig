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
        const total = @as(usize, rows) * @as(usize, cols);
        const data = try allocator.alloc(u8, total);
        @memset(data, 0);
        return .{
            .rows = rows,
            .cols = cols,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn identity(allocator: std.mem.Allocator, size: u32) !OctetMatrix {
        var m = try init(allocator, size, size);
        var i: u32 = 0;
        while (i < size) : (i += 1) {
            m.set(i, i, Octet.ONE);
        }
        return m;
    }

    pub fn deinit(self: OctetMatrix) void {
        self.allocator.free(self.data);
    }

    fn offset(self: OctetMatrix, row: u32, col: u32) usize {
        return @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
    }

    pub fn rowSlice(self: OctetMatrix, row: u32) []u8 {
        const off = @as(usize, row) * @as(usize, self.cols);
        return self.data[off..][0..self.cols];
    }

    pub fn rowSliceConst(self: OctetMatrix, row: u32) []const u8 {
        const off = @as(usize, row) * @as(usize, self.cols);
        return self.data[off..][0..self.cols];
    }

    pub fn get(self: OctetMatrix, row: u32, col: u32) Octet {
        return Octet.init(self.data[self.offset(row, col)]);
    }

    pub fn set(self: *OctetMatrix, row: u32, col: u32, val: Octet) void {
        self.data[self.offset(row, col)] = val.value;
    }

    pub fn swapRows(self: *OctetMatrix, i: u32, j: u32) void {
        if (i == j) return;
        const row_i = self.rowSlice(i);
        const row_j = self.rowSlice(j);
        for (row_i, row_j) |*a, *b| {
            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;
        }
    }

    pub fn addAssignRow(self: *OctetMatrix, src: u32, dst: u32) void {
        octets_mod.addAssign(self.rowSlice(dst), self.rowSliceConst(src));
    }

    pub fn fmaRow(self: *OctetMatrix, src: u32, dst: u32, scalar: Octet) void {
        octets_mod.fmaSlice(self.rowSlice(dst), self.rowSliceConst(src), scalar);
    }

    pub fn mulAssignRow(self: *OctetMatrix, row: u32, scalar: Octet) void {
        octets_mod.mulAssignScalar(self.rowSlice(row), scalar);
    }

    pub fn numRows(self: OctetMatrix) u32 {
        return self.rows;
    }

    pub fn numCols(self: OctetMatrix) u32 {
        return self.cols;
    }
};

test "OctetMatrix get/set" {
    var m = try OctetMatrix.init(std.testing.allocator, 3, 4);
    defer m.deinit();

    try std.testing.expect(m.get(0, 0).isZero());
    m.set(0, 0, Octet.init(42));
    try std.testing.expectEqual(@as(u8, 42), m.get(0, 0).value);

    m.set(2, 3, Octet.init(255));
    try std.testing.expectEqual(@as(u8, 255), m.get(2, 3).value);
}

test "OctetMatrix identity" {
    var m = try OctetMatrix.identity(std.testing.allocator, 3);
    defer m.deinit();

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        var j: u32 = 0;
        while (j < 3) : (j += 1) {
            if (i == j) {
                try std.testing.expect(m.get(i, j).isOne());
            } else {
                try std.testing.expect(m.get(i, j).isZero());
            }
        }
    }
}

test "OctetMatrix swapRows" {
    var m = try OctetMatrix.init(std.testing.allocator, 2, 3);
    defer m.deinit();

    m.set(0, 0, Octet.init(1));
    m.set(0, 1, Octet.init(2));
    m.set(1, 0, Octet.init(3));
    m.set(1, 1, Octet.init(4));

    m.swapRows(0, 1);
    try std.testing.expectEqual(@as(u8, 3), m.get(0, 0).value);
    try std.testing.expectEqual(@as(u8, 4), m.get(0, 1).value);
    try std.testing.expectEqual(@as(u8, 1), m.get(1, 0).value);
    try std.testing.expectEqual(@as(u8, 2), m.get(1, 1).value);
}

test "OctetMatrix addAssignRow" {
    var m = try OctetMatrix.init(std.testing.allocator, 2, 3);
    defer m.deinit();

    m.set(0, 0, Octet.init(0x0A));
    m.set(0, 1, Octet.init(0x0B));
    m.set(1, 0, Octet.init(0x0C));
    m.set(1, 1, Octet.init(0x0D));

    m.addAssignRow(0, 1);
    // GF(256) add = XOR
    try std.testing.expectEqual(@as(u8, 0x0A ^ 0x0C), m.get(1, 0).value);
    try std.testing.expectEqual(@as(u8, 0x0B ^ 0x0D), m.get(1, 1).value);
}

test "OctetMatrix mulAssignRow" {
    var m = try OctetMatrix.init(std.testing.allocator, 1, 3);
    defer m.deinit();

    m.set(0, 0, Octet.ONE);
    m.set(0, 1, Octet.init(2));
    m.set(0, 2, Octet.ZERO);

    m.mulAssignRow(0, Octet.init(3));

    try std.testing.expectEqual(Octet.init(3), m.get(0, 0));
    try std.testing.expectEqual(Octet.init(2).mul(Octet.init(3)), m.get(0, 1));
    try std.testing.expect(m.get(0, 2).isZero());
}
