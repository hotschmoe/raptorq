// Encoding symbol with GF(256) field arithmetic

const std = @import("std");
const Octet = @import("../math/octet.zig").Octet;
const octets = @import("../math/octets.zig");

pub const Symbol = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Symbol {
        const data = try allocator.alloc(u8, size);
        @memset(data, 0);
        return .{ .data = data, .allocator = allocator };
    }

    pub fn fromSlice(allocator: std.mem.Allocator, src: []const u8) !Symbol {
        const data = try allocator.alloc(u8, src.len);
        @memcpy(data, src);
        return .{ .data = data, .allocator = allocator };
    }

    pub fn deinit(self: Symbol) void {
        self.allocator.free(self.data);
    }

    pub fn clone(self: Symbol) !Symbol {
        return fromSlice(self.allocator, self.data);
    }

    pub fn addAssign(self: *Symbol, other: Symbol) void {
        octets.addAssign(self.data, other.data);
    }

    pub fn mulAssign(self: *Symbol, scalar: Octet) void {
        octets.mulAssignScalar(self.data, scalar);
    }

    pub fn fma(self: *Symbol, other: Symbol, scalar: Octet) void {
        octets.fmaSlice(self.data, other.data, scalar);
    }

    pub fn len(self: Symbol) usize {
        return self.data.len;
    }
};
