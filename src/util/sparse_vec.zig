// Sparse binary vector using sorted index list

const std = @import("std");

pub const SparseBinaryVec = struct {
    indices: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) SparseBinaryVec {
        return .{ .indices = std.ArrayList(u32).init(allocator) };
    }

    pub fn deinit(self: *SparseBinaryVec) void {
        self.indices.deinit();
    }

    pub fn get(self: SparseBinaryVec, index: u32) bool {
        _ = .{ self, index };
        @panic("TODO");
    }

    pub fn set(self: *SparseBinaryVec, index: u32) void {
        _ = .{ self, index };
        @panic("TODO");
    }

    pub fn unset(self: *SparseBinaryVec, index: u32) void {
        _ = .{ self, index };
        @panic("TODO");
    }

    pub fn count(self: SparseBinaryVec) usize {
        return self.indices.items.len;
    }

    pub fn xorWith(self: *SparseBinaryVec, other: SparseBinaryVec) void {
        _ = .{ self, other };
        @panic("TODO");
    }
};
